import './index.css';
import { RouterProvider } from '@tanstack/solid-router';
import { render } from 'solid-js/web';
import { router } from './router';

const root = document.getElementById('root');
if (!root) throw new Error('#root element missing from index.html');

render(() => <RouterProvider router={router} />, root);
